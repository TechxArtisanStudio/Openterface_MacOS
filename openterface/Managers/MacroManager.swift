import Foundation
import AppKit

enum MacroTargetSystem: String, Codable, CaseIterable, Identifiable {
    case macOS
    case windows
    case linux
    case iPhone
    case iPad
    case android

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .android: return "Android"
        }
    }
}

// MARK: - Macro

/// A keyboard macro that can be triggered as a quick action.
///
/// The `data` field uses a simple token syntax for special keys:
/// - `<CTRL>c</CTRL>` : press Ctrl+C
/// - `<ESC>` : Escape key
/// - `<ENTER>` : Enter key
/// - `<DELAY05s>` : pause 0.5 second
/// - `<DELAY1S>` : pause 1 second
/// - Regular characters are sent as-is
struct Macro: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var description: String
    var isVerified: Bool
    var data: String      /// key sequence with optional `<TOKEN>` tags
    var icon: String      /// SF Symbol name
    var targetSystem: MacroTargetSystem
    var intervalMs: Int   /// delay between each token in milliseconds

    init(id: UUID = UUID(),
         label: String,
         description: String = "",
         isVerified: Bool = false,
         data: String,
         icon: String = "keyboard",
         targetSystem: MacroTargetSystem = .macOS,
         intervalMs: Int = 80) {
        self.id = id
        self.label = label
        self.description = description
        self.isVerified = isVerified
        self.data = data
        self.icon = icon
        self.targetSystem = targetSystem
        self.intervalMs = intervalMs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case description
        case isVerified
        case data
        case icon
        case targetSystem
        case intervalMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        data = try container.decode(String.self, forKey: .data)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "keyboard"
        targetSystem = try container.decodeIfPresent(MacroTargetSystem.self, forKey: .targetSystem) ?? .macOS
        intervalMs = try container.decodeIfPresent(Int.self, forKey: .intervalMs) ?? 80
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(description, forKey: .description)
        try container.encode(isVerified, forKey: .isVerified)
        try container.encode(data, forKey: .data)
        try container.encode(icon, forKey: .icon)
        try container.encode(targetSystem, forKey: .targetSystem)
        try container.encode(intervalMs, forKey: .intervalMs)
    }
}

// MARK: - MacroManager

@MainActor
final class MacroManager: ObservableObject {
    static let shared = MacroManager()

    @Published var macros: [Macro] = [] {
        didSet { persist() }
    }

    private let defaultsKey = "Macros_v1"

    private init() { load() }

    // MARK: CRUD

    func add(_ macro: Macro) {
        macros.append(macro)
    }

    func update(_ macro: Macro, at index: Int) {
        guard macros.indices.contains(index) else { return }
        macros[index] = macro
    }

    func remove(at index: Int) {
        guard macros.indices.contains(index) else { return }
        macros.remove(at: index)
    }

    // MARK: Execution

    func execute(_ macro: Macro) {
        let macrosByID = Dictionary(uniqueKeysWithValues: macros.map { ($0.id, $0) })
        let tokens = expandedTokens(for: macro, macrosByID: macrosByID, visited: [macro.id])
        let interval = macro.intervalMs
        DispatchQueue.global(qos: .userInitiated).async {
            MacroExecutionEngine.run(tokens: tokens, intervalMs: interval)
        }
    }

    /// Returns the estimated wall-clock time (in seconds) that the macro's
    /// keystroke sequence will take to execute on the target machine.
    func estimatedExecutionDuration(for macro: Macro) -> TimeInterval {
        let macrosByID = Dictionary(uniqueKeysWithValues: macros.map { ($0.id, $0) })
        let tokens = expandedTokens(for: macro, macrosByID: macrosByID, visited: [macro.id])
        let intervalMs = max(10, macro.intervalMs)

        let delayDurations: [String: Int] = [
            "<DELAY05s>": 500,
            "<DELAY1S>": 1000,
            "<DELAY2S>": 2000,
            "<DELAY5S>": 5000,
            "<DELAY10S>": 10000
        ]

        var totalMs = 0
        for token in tokens {
            if let delay = delayDurations[token] {
                totalMs += delay
            } else {
                totalMs += intervalMs
            }
        }
        return TimeInterval(totalMs) / 1000.0
    }

    private func expandedTokens(for macro: Macro, macrosByID: [UUID: Macro], visited: Set<UUID>) -> [String] {
        var expanded: [String] = []

        for token in tokenize(macro.data) {
            guard let referencedID = macroReferenceID(from: token),
                  let referencedMacro = macrosByID[referencedID],
                  !visited.contains(referencedID) else {
                if macroReferenceID(from: token) == nil {
                    expanded.append(token)
                }
                continue
            }

            expanded.append(contentsOf: expandedTokens(
                for: referencedMacro,
                macrosByID: macrosByID,
                visited: visited.union([referencedID])
            ))
        }

        return expanded
    }

    // MARK: Tokenizer

    /// Splits the data string into special tokens (`<TAG>`, `</TAG>`) and individual characters.
    func tokenize(_ str: String) -> [String] {
        // Accept both uppercase and lowercase token names (e.g. <ctrl>, <CMD>, <Super>).
        guard let regex = try? NSRegularExpression(pattern: "</?[A-Za-z][A-Za-z0-9]*(?::[A-Za-z0-9-]+)?>") else {
            return str.map { String($0) }
        }
        let nsStr = str as NSString
        var result: [String] = []
        var lastIndex = 0
        for match in regex.matches(in: str, range: NSRange(location: 0, length: nsStr.length)) {
            let r = match.range
            if r.location > lastIndex {
                let plain = nsStr.substring(with: NSRange(location: lastIndex, length: r.location - lastIndex))
                result.append(contentsOf: plain.map { String($0) })
            }
            result.append(nsStr.substring(with: r))
            lastIndex = r.location + r.length
        }
        if lastIndex < nsStr.length {
            result.append(contentsOf: nsStr.substring(from: lastIndex).map { String($0) })
        }
        return result
    }

    private func macroReferenceID(from token: String) -> UUID? {
        let upper = token.uppercased()
        guard upper.hasPrefix("<MACRO:"), token.hasSuffix(">") else { return nil }
        let startIndex = token.index(token.startIndex, offsetBy: 7)
        let endIndex = token.index(before: token.endIndex)
        return UUID(uuidString: String(token[startIndex..<endIndex]))
    }

    // MARK: Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([Macro].self, from: data)
        else { return }
        macros = saved
    }
}

// MARK: - MacroExecutionEngine

/// Static execution engine — no actor isolation, safe to call from background threads.
private struct MacroExecutionEngine {

    /// Canonicalize tokens to a single form so execution is case-insensitive and
    /// common modifier aliases resolve consistently.
    private static func canonicalToken(_ token: String) -> String {
        guard token.hasPrefix("<"), token.hasSuffix(">") else { return token }

        let isClosing = token.hasPrefix("</")
        let nameStart = token.index(token.startIndex, offsetBy: isClosing ? 2 : 1)
        let nameEnd = token.index(before: token.endIndex)
        let rawName = String(token[nameStart..<nameEnd]).uppercased()

        let canonicalName: String
        switch rawName {
        case "CTRL", "CONTROL":
            canonicalName = "CTRL"
        case "SHIFT":
            canonicalName = "SHIFT"
        case "ALT", "OPT", "OPTION":
            canonicalName = "ALT"
        case "CMD", "COMMAND", "WIN", "SUPER", "META":
            canonicalName = "CMD"
        default:
            canonicalName = rawName
        }

        return isClosing ? "</\(canonicalName)>" : "<\(canonicalName)>"
    }

    static func run(tokens: [String], intervalMs: Int) {
        let isVNC = AppStatus.activeConnectionProtocol == .vnc
        var pending: NSEvent.ModifierFlags = []

        let delaySet: Set<String> = ["<DELAY05S>", "<DELAY1S>", "<DELAY2S>", "<DELAY5S>", "<DELAY10S>"]

        for token in tokens {
            let normalizedToken = canonicalToken(token)
            switch normalizedToken {

            // ── Open modifier tags ──────────────────────────────────────────
            case "<CTRL>":  pending.insert(.control)
            case "<SHIFT>": pending.insert(.shift)
            case "<ALT>":   pending.insert(.option)
            case "<CMD>":   pending.insert(.command)

            // ── Close modifier tags ─────────────────────────────────────────
            case "</CTRL>":  pending.remove(.control)
            case "</SHIFT>": pending.remove(.shift)
            case "</ALT>":   pending.remove(.option)
            case "</CMD>":   pending.remove(.command)

            // ── Named special keys ──────────────────────────────────────────
            case "<ESC>":   sendKey(53,  0xFF1B, pending, isVNC)
            case "<BACK>":  sendKey(51,  0xFF08, pending, isVNC)
            case "<ENTER>": sendKey(36,  0xFF0D, pending, isVNC)
            case "<TAB>":   sendKey(48,  0xFF09, pending, isVNC)
            case "<SPACE>": sendKey(49,  0x0020, pending, isVNC)
            case "<LEFT>":  sendKey(123, 0xFF51, pending, isVNC)
            case "<RIGHT>": sendKey(124, 0xFF53, pending, isVNC)
            case "<UP>":    sendKey(126, 0xFF52, pending, isVNC)
            case "<DOWN>":  sendKey(125, 0xFF54, pending, isVNC)
            case "<HOME>":  sendKey(115, 0xFF50, pending, isVNC)
            case "<END>":   sendKey(119, 0xFF57, pending, isVNC)
            case "<DEL>":   sendKey(117, 0xFFFF, pending, isVNC)
            case "<PGUP>":  sendKey(116, 0xFF55, pending, isVNC)
            case "<PGDN>":  sendKey(121, 0xFF56, pending, isVNC)
            case "<F1>":    sendKey(122, 0xFFBE, pending, isVNC)
            case "<F2>":    sendKey(120, 0xFFBF, pending, isVNC)
            case "<F3>":    sendKey(99,  0xFFC0, pending, isVNC)
            case "<F4>":    sendKey(118, 0xFFC1, pending, isVNC)
            case "<F5>":    sendKey(96,  0xFFC2, pending, isVNC)
            case "<F6>":    sendKey(97,  0xFFC3, pending, isVNC)
            case "<F7>":    sendKey(98,  0xFFC4, pending, isVNC)
            case "<F8>":    sendKey(100, 0xFFC5, pending, isVNC)
            case "<F9>":    sendKey(101, 0xFFC6, pending, isVNC)
            case "<F10>":   sendKey(109, 0xFFC7, pending, isVNC)
            case "<F11>":   sendKey(103, 0xFFC8, pending, isVNC)
            case "<F12>":   sendKey(111, 0xFFC9, pending, isVNC)

            // ── Delays ──────────────────────────────────────────────────────
            case "<DELAY05S>": usleep(500_000)
            case "<DELAY1S>":  usleep(1_000_000)
            case "<DELAY2S>":  usleep(2_000_000)
            case "<DELAY5S>":  usleep(5_000_000)
            case "<DELAY10S>": usleep(10_000_000)

            // ── Plain character ─────────────────────────────────────────────
            default:
                guard token.count == 1 else { continue }
                if pending.isEmpty {
                    sendText(token, isVNC: isVNC)
                } else {
                    sendCharWithModifiers(token, modifiers: pending, isVNC: isVNC)
                }
            }

            // Inter-token delay (skip for explicit delay tokens)
            if !delaySet.contains(normalizedToken) {
                usleep(useconds_t(max(10, intervalMs) * 1_000))
            }
        }
    }

    // MARK: Private send helpers

    private static func sendText(_ text: String, isVNC: Bool) {
        if isVNC {
            for scalar in text.unicodeScalars {
                let ks = vncKeySym(for: scalar)
                VNCClientManager.shared.sendKeyEvent(keySym: ks, isDown: true)
                usleep(15_000)
                VNCClientManager.shared.sendKeyEvent(keySym: ks, isDown: false)
                usleep(15_000)
            }
        } else {
            KeyboardManager.shared.sendTextToKeyboard(text: text)
        }
    }

    private static func sendKey(_ keyCode: UInt16, _ keySym: UInt32,
                                _ modifiers: NSEvent.ModifierFlags, _ isVNC: Bool) {
        if isVNC {
            let mods = vncModSyms(from: modifiers)
            for sym in mods { VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: true) }
            VNCClientManager.shared.sendKeyEvent(keySym: keySym, isDown: true)
            usleep(50_000)
            VNCClientManager.shared.sendKeyEvent(keySym: keySym, isDown: false)
            for sym in mods.reversed() { VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: false) }
        } else {
            HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: true)
            usleep(50_000)
            HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: false)
        }
    }

    private static func sendCharWithModifiers(_ char: String, modifiers: NSEvent.ModifierFlags, isVNC: Bool) {
        let lower = char.lowercased()
        var resolvedMods = modifiers
        if char != lower { resolvedMods.insert(.shift) }

        if isVNC {
            guard let scalar = char.unicodeScalars.first else { return }
            let charSym = vncKeySym(for: scalar)
            let mods = vncModSyms(from: resolvedMods)
            for sym in mods { VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: true) }
            VNCClientManager.shared.sendKeyEvent(keySym: charSym, isDown: true)
            usleep(50_000)
            VNCClientManager.shared.sendKeyEvent(keySym: charSym, isDown: false)
            for sym in mods.reversed() { VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: false) }
        } else {
            let map: [String: UInt16] = [
                "a": 0,  "b": 11, "c": 8,  "d": 2,  "e": 14, "f": 3,  "g": 5,
                "h": 4,  "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
                "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,  "t": 17, "u": 32,
                "v": 9,  "w": 13, "x": 7,  "y": 16, "z": 6,
                "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
                "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
            ]
            if let kc = map[lower] {
                HostManager.shared.handleKeyboardEvent(keyCode: kc, modifierFlags: resolvedMods, isKeyDown: true)
                usleep(50_000)
                HostManager.shared.handleKeyboardEvent(keyCode: kc, modifierFlags: resolvedMods, isKeyDown: false)
            } else {
                KeyboardManager.shared.sendTextToKeyboard(text: char)
            }
        }
    }

    // MARK: VNC helpers

    private static func vncKeySym(for scalar: UnicodeScalar) -> UInt32 {
        switch scalar {
        case "\n", "\r": return 0xFF0D
        case "\t":       return 0xFF09
        default:         return scalar.value
        }
    }

    private static func vncModSyms(from modifiers: NSEvent.ModifierFlags) -> [UInt32] {
        let f = modifiers.intersection(.deviceIndependentFlagsMask)
        var syms: [UInt32] = []
        if f.contains(.control) { syms.append(0xFFE3) }
        if f.contains(.option)  { syms.append(0xFFE9) }
        if f.contains(.shift)   { syms.append(0xFFE1) }
        if f.contains(.command) { syms.append(0xFFEB) }
        return syms
    }
}
