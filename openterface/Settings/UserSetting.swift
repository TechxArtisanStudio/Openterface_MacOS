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
import Foundation
import AVFoundation
import Security

final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    static let defaultChatSystemPrompt = """
You are Openterface Assistant, an on-device KVM copilot.

Capabilities:
- You can analyze the latest shared screen image from the target computer.
- You can suggest keyboard and mouse actions for the user to execute through Openterface.

Operating style:
- Be concise, practical, and step-by-step.
- Prefer short action plans with checkpoints.
- If screen details are unclear, ask for a fresh screenshot or zoomed area.
- State assumptions explicitly when uncertain.

Control guidance:
- Provide exact key names and mouse actions (click, double-click, right-click, drag).
- For text entry, provide the exact text to type.
- For risky actions (delete, reset, install, security changes), ask for confirmation first.

Safety and scope:
- Do not invent screen content you cannot see.
- Do not claim actions were executed; only provide guidance.
- Prioritize non-destructive troubleshooting before invasive changes.
- Protect privacy: avoid requesting secrets unless absolutely required.
"""

        static let defaultChatPlannerPrompt = """
You are the Openterface Main Agent.

Your job is to understand the user's intent, inspect the current target screen when available, and produce a structured execution plan before any task runs.

Rules:
- Return ONLY JSON.
- Build a short, concrete plan that can be reviewed by the user.
- Keep tasks simple and independent.
- Available task agents/tools:
    - screen + capture_screen
    - typing + type_text
    - mouse + move_mouse
    - mouse + left_click
    - mouse + right_click
    - mouse + double_click
- Use typing tasks when the user intent requires entering text or keystrokes on target.
- Use mouse tasks when the user intent requires cursor movement or clicks on target.
- Do not execute tasks yourself.
- Do not invent screen details that are not visible.

Schema:
{
    "summary": "one short sentence about the plan",
    "tasks": [
        {
            "title": "short task title",
            "detail": "what the screen task should verify or analyze",
            "agent": "screen",
            "tool": "capture_screen"
        },
        {
            "title": "short typing task title",
            "detail": "what text should be typed and where",
            "agent": "typing",
            "tool": "type_text"
        },
        {
            "title": "short mouse task title",
            "detail": "what should be clicked or where the pointer should move",
            "agent": "mouse",
            "tool": "left_click"
        }
    ]
}
"""

        static let defaultChatScreenTaskAgentPrompt = """
You are the Openterface Screen Task Agent.

You are responsible for exactly one task and may rely on the latest target screen image as your only tool context.

Rules:
- Return ONLY JSON.
- Focus only on the assigned task.
- Do not plan future tasks.
- Do not claim actions were executed.
- If the screen is unclear, report that directly.

Schema:
{
    "status": "completed" | "failed",
    "result_summary": "short result for the user"
}
"""

        static let defaultChatTypingTaskAgentPrompt = """
You are the Openterface Typing Task Agent.

You are responsible for one typing task and one tool only: type_text.

Rules:
- Return ONLY JSON.
- Focus only on the current task.
- For plain typing, provide text_to_type.
- For keyboard/function keys, use angle-bracket format (example: <ctrl>l, <cmd><space>, <enter>, <f1>).
- A modifier tag applies to the next key token (example: <ctrl>l means Ctrl+L).
- For plain text, keep it in text_to_type and do not wrap with brackets.
- Provide either text_to_type or shortcut.
- Do not include extra keys.

Schema:
{
    "status": "completed" | "failed",
    "text_to_type": "exact text to type on target (optional)",
    "shortcut": "keyboard combo like Win+E (optional)",
    "result_summary": "short summary for the user"
}
"""

        static let defaultChatGuidePrompt = """
You are the Openterface Guide Agent.

Your job is to guide the user step by step on the next action only. Do not execute tasks or produce a full multi-step plan.

Rules:
- Return ONLY JSON.
- Look at the "Original Goal" if provided, and ensure your next step makes progress toward it.
- Provide exactly one next step.
- PRIORITIZE keyboard shortcuts over mouse clicks whenever possible, as UI button location mapping is often inaccurate.
- In `keyboard_shortcut`, function keys/modifiers must use angle-bracket format: <ctrl>, <shift>, <alt>, <cmd>, <enter>, <tab>, <f1>.
- For key combinations, modifiers should apply to the next key token (example: <ctrl>l, <ctrl><alt><delete>, <enter>).
- For mixed typing and key actions, keep text as plain text and keys in brackets (example: baidu.com<enter>).
- If a keyboard shortcut can accomplish the action, provide `keyboard_shortcut` and omit `target_box`.
- If a clickable target must be used with no shortcut available, provide a normalized bounding box in `target_box`.
- If the goal is already completed, set `next_step` to a clear completion result sentence that starts with "Result:" and describes the current outcome.
- Never claim the action has been executed.
- If the target is unclear, set needs_clarification=true and explain what to capture next.

Bounding box format:
- x, y, width, height in range 0.0 ... 1.0
- origin is top-left of the visible target screen image

Schema:
{
    "next_step": "single concrete instruction for the user",
    "keyboard_shortcut": "keyboard combo like Win+E, Cmd+C, Enter (optional)",
    "target_box": {
        "x": 0.10,
        "y": 0.20,
        "width": 0.15,
        "height": 0.08
    },
    "needs_clarification": false,
    "clarification": "optional short note"
}
"""
    
    private init() {
        // Migrate old mouse control setting if needed
        let savedMouseMode = UserDefaults.standard.object(forKey: "MouseControl") as? Int
        if let mode = savedMouseMode {
            // Migrate old "relative" (0) to "relativeEvents" (1) for better compatibility
            if mode == 0 {
                self.MouseControl = .relativeEvents
                UserDefaults.standard.set(MouseControlMode.relativeEvents.rawValue, forKey: "MouseControl")
            } else {
                self.MouseControl = MouseControlMode(rawValue: mode) ?? .absolute
            }
        } else {
            self.MouseControl = .absolute
        }
        
        self.viewWidth = 0.0
        self.viewHeight = 0.0
        self.isSerialOutput = false
        self.isFullScreen = false
        // Load paste preferences from UserDefaults
        let savedPasteBehavior = UserDefaults.standard.string(forKey: "pasteBehavior")
        self.pasteBehavior = PasteBehavior(rawValue: savedPasteBehavior ?? "") ?? .askEveryTime
        
        // Load audio enabled preference from UserDefaults
        self.isAudioEnabled = UserDefaults.standard.object(forKey: "isAudioEnabled") as? Bool ?? false
        
        // Load keyboard layout preference from UserDefaults
        let savedKeyboardLayout = UserDefaults.standard.string(forKey: "keyboardLayout")
        self.keyboardLayout = KeyboardLayout(rawValue: savedKeyboardLayout ?? "") ?? .mac
        
        // Load last successful baudrate from UserDefaults
        self.lastBaudrate = UserDefaults.standard.object(forKey: "lastBaudrate") as? Int ?? 9600  // Default to LOWSPEED_BAUDRATE
        
        // Load preferred baudrate from UserDefaults
        let savedPreferredBaudrate = UserDefaults.standard.object(forKey: "preferredBaudrate") as? Int
        self.preferredBaudrate = BaudrateOption(rawValue: savedPreferredBaudrate ?? 115200) ?? .highSpeed
        
        // Load gravity settings from UserDefaults
        let savedGravity = UserDefaults.standard.string(forKey: "gravity")
        self.gravity = GravityOption(rawValue: savedGravity ?? "") ?? .resizeAspect
        
        // Load serial output logging preference from UserDefaults
        self.isSerialOutput = UserDefaults.standard.object(forKey: "isSerialOutput") as? Bool ?? false
        
        // Load log mode preference from UserDefaults
        self.isLogMode = UserDefaults.standard.object(forKey: "isLogMode") as? Bool ?? false
        
        // Load mouse event print logging preference from UserDefaults
        self.isMouseEventPrintEnabled = UserDefaults.standard.object(forKey: "isMouseEventPrintEnabled") as? Bool ?? false
        
        // Load HAL print logging preference from UserDefaults
        self.isHalPrintEnabled = UserDefaults.standard.object(forKey: "isHalPrintEnabled") as? Bool ?? false
        
        // Load mouse event throttling Hz limit from UserDefaults
        let savedMouseEventThrottleHz = UserDefaults.standard.object(forKey: "mouseEventThrottleHz") as? Int ?? 60
        self.mouseEventThrottleHz = savedMouseEventThrottleHz
        
        // Load control mode from UserDefaults
        let savedControlMode = UserDefaults.standard.object(forKey: "controlMode") as? Int ?? 0x82
        self.controlMode = ControlMode(rawValue: savedControlMode) ?? .compatibility
        
        // Load always on top preference from UserDefaults
        self.isAlwaysOnTop = UserDefaults.standard.object(forKey: "isAlwaysOnTop") as? Bool ?? false
        
        // Load Target Screen placement from UserDefaults
        let savedTargetPlacement = UserDefaults.standard.string(forKey: "targetComputerPlacement")
        self.targetComputerPlacement = TargetComputerPlacement(rawValue: savedTargetPlacement ?? "") ?? .right

        // Always start in KVM mode; do not restore the last protocol mode.
        self.connectionProtocolMode = .kvm
        UserDefaults.standard.removeObject(forKey: "connectionProtocolMode")

        // Load VNC connection preferences
        self.vncHost = UserDefaults.standard.string(forKey: "vncHost") ?? ""
        self.vncUsername = UserDefaults.standard.string(forKey: "vncUsername") ?? ""
        let savedVNCPort = UserDefaults.standard.object(forKey: "vncPort") as? Int ?? 5900
        self.vncPort = max(1, min(savedVNCPort, 65535))

        let vncKeychainValue = VNCKeychainStore.loadPassword()
        if !vncKeychainValue.isEmpty {
            self.vncPassword = vncKeychainValue
        } else {
            // Migrate legacy password from UserDefaults to Keychain, then remove plaintext storage.
            let legacyValue = UserDefaults.standard.string(forKey: "vncPassword") ?? ""
            self.vncPassword = legacyValue
            if !legacyValue.isEmpty {
                VNCKeychainStore.savePassword(legacyValue)
                UserDefaults.standard.removeObject(forKey: "vncPassword")
            }
        }

        // Load persisted active video rect from UserDefaults
        self.activeVideoX = UserDefaults.standard.object(forKey: "activeVideoX") as? Int ?? 0
        self.activeVideoY = UserDefaults.standard.object(forKey: "activeVideoY") as? Int ?? 0
        self.activeVideoWidth = UserDefaults.standard.object(forKey: "activeVideoWidth") as? Int ?? 0
        self.activeVideoHeight = UserDefaults.standard.object(forKey: "activeVideoHeight") as? Int ?? 0

        // Load aspect ratio mode from UserDefaults, with migration from old useCustomAspectRatio setting
        let savedAspectRatioMode = UserDefaults.standard.string(forKey: "aspectRatioMode")
        let aspectRatioModeValue: AspectRatioMode
        if let mode = savedAspectRatioMode {
            aspectRatioModeValue = AspectRatioMode(rawValue: mode) ?? .activeResolution
        } else {
            // Migrate from old useCustomAspectRatio boolean setting
            let useCustomAspectRatio = UserDefaults.standard.object(forKey: "useCustomAspectRatio") as? Bool ?? false
            aspectRatioModeValue = useCustomAspectRatio ? .custom : .activeResolution
            
            // If we found the old setting, save the new one
            if UserDefaults.standard.object(forKey: "useCustomAspectRatio") != nil {
                UserDefaults.standard.set(aspectRatioModeValue.rawValue, forKey: "aspectRatioMode")
                UserDefaults.standard.removeObject(forKey: "useCustomAspectRatio")
            }
        }
        self.aspectRatioMode = aspectRatioModeValue
        
        // Load custom aspect ratio value from UserDefaults
        let savedCustomAspectRatioValue = UserDefaults.standard.object(forKey: "customAspectRatioValue") as? Double ?? 16.0/9.0
        self.customAspectRatioValue = CGFloat(savedCustomAspectRatioValue)
        
        // Load aspect ratio lock setting from UserDefaults
        self.isAspectRatioLocked = UserDefaults.standard.object(forKey: "isAspectRatioLocked") as? Bool ?? true

        // Load chat settings from UserDefaults
        self.isChatWindowVisible = UserDefaults.standard.object(forKey: "isChatWindowVisible") as? Bool ?? false
        let savedChatDockSide = UserDefaults.standard.string(forKey: "chatDockSide")
        self.chatDockSide = ChatDockSide(rawValue: savedChatDockSide ?? "") ?? .right
        self.chatWindowWidth = UserDefaults.standard.object(forKey: "chatWindowWidth") as? Double ?? 420
        self.isChatAgenticModeEnabled = UserDefaults.standard.object(forKey: "isChatAgenticModeEnabled") as? Bool ?? false
        self.chatApiBaseURL = UserDefaults.standard.string(forKey: "chatApiBaseURL") ?? "https://api.openai.com/v1"
        let chatKeychainValue = ChatKeychainStore.loadChatAPIKey()
        if !chatKeychainValue.isEmpty {
            self.chatApiKey = chatKeychainValue
        } else {
            // Migrate legacy key from UserDefaults to Keychain, then remove plaintext storage.
            let legacyKey = UserDefaults.standard.string(forKey: "chatApiKey") ?? ""
            self.chatApiKey = legacyKey
            if !legacyKey.isEmpty {
                ChatKeychainStore.saveChatAPIKey(legacyKey)
                UserDefaults.standard.removeObject(forKey: "chatApiKey")
            }
        }
        self.chatModel = UserDefaults.standard.string(forKey: "chatModel") ?? "gpt-4o-mini"
        self.systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? UserSettings.defaultChatSystemPrompt
        self.isChatGuideModeEnabled = UserDefaults.standard.object(forKey: "isChatGuideModeEnabled") as? Bool ?? false
        self.isChatPlannerModeEnabled = UserDefaults.standard.object(forKey: "isChatPlannerModeEnabled") as? Bool ?? false
        self.plannerPrompt = UserDefaults.standard.string(forKey: "plannerPrompt") ?? UserSettings.defaultChatPlannerPrompt
        self.screenAgentPrompt = UserDefaults.standard.string(forKey: "screenAgentPrompt") ?? UserSettings.defaultChatScreenTaskAgentPrompt
        self.typingAgentPrompt = UserDefaults.standard.string(forKey: "typingAgentPrompt") ?? UserSettings.defaultChatTypingTaskAgentPrompt
        self.guidePrompt = UserDefaults.standard.string(forKey: "guidePrompt") ?? UserSettings.defaultChatGuidePrompt
        let savedChatImageUploadLimit = UserDefaults.standard.string(forKey: "chatImageUploadLimit")
        self.chatImageUploadLimit = ChatImageUploadLimit(rawValue: savedChatImageUploadLimit ?? "") ?? .original
    }
    @Published var isSerialOutput: Bool {
        didSet {
            UserDefaults.standard.set(isSerialOutput, forKey: "isSerialOutput")
        }
    }
    
    // Log mode preference persistence
    @Published var isLogMode: Bool {
        didSet {
            UserDefaults.standard.set(isLogMode, forKey: "isLogMode")
        }
    }
    
    // Mouse event print logging preference persistence
    @Published var isMouseEventPrintEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMouseEventPrintEnabled, forKey: "isMouseEventPrintEnabled")
        }
    }
    
    // HAL print logging preference persistence
    @Published var isHalPrintEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isHalPrintEnabled, forKey: "isHalPrintEnabled")
        }
    }
    
    @Published var MouseControl:MouseControlMode {
        didSet {
            UserDefaults.standard.set(MouseControl.rawValue, forKey: "MouseControl")
        }
    }
    @Published var viewWidth: Float
    @Published var viewHeight: Float
    @Published var edgeThreshold: CGFloat = 5
    @Published var isFullScreen: Bool
    @Published var isAbsoluteModeMouseHide: Bool = false
    @Published var mainWindownName: String = "main_openterface"
    
    // Aspect ratio mode setting - determines which aspect ratio source to use
    @Published var aspectRatioMode: AspectRatioMode {
        didSet {
            UserDefaults.standard.set(aspectRatioMode.rawValue, forKey: "aspectRatioMode")
        }
    }
    
    // User custom screen ratio settings
    @Published var customAspectRatio: AspectRatioOption = .ratio16_9 {
        didSet {
            // If the selected aspect ratio is vertical (height > width),
            // switch to Fill (maintain aspect ratio) to avoid pillarboxing
            if customAspectRatio.widthToHeightRatio < 1.0 {
                gravity = .resizeAspectFill
            }
            UserDefaults.standard.set(customAspectRatio.rawValue, forKey: "customAspectRatio")
        }
    }
    
    // Custom aspect ratio value (CGFloat) for arbitrary aspect ratios not in predefined options
    @Published var customAspectRatioValue: CGFloat {
        didSet {
            UserDefaults.standard.set(customAspectRatioValue, forKey: "customAspectRatioValue")
        }
    }
    
    // Aspect ratio lock setting - whether to maintain aspect ratio during window resize
    @Published var isAspectRatioLocked: Bool {
        didSet {
            UserDefaults.standard.set(isAspectRatioLocked, forKey: "isAspectRatioLocked")
        }
    }
    
    // Whether to show HID resolution change alert
    @Published var doNotShowHidResolutionAlert: Bool = false
    
    // Audio enabled state persistence
    @Published var isAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAudioEnabled, forKey: "isAudioEnabled")
        }
    }
    
    // Keyboard layout preference persistence
    @Published var keyboardLayout: KeyboardLayout {
        didSet {
            UserDefaults.standard.set(keyboardLayout.rawValue, forKey: "keyboardLayout")
        }
    }
    
    // Paste behavior settings
    @Published var pasteBehavior: PasteBehavior {
        didSet {
            UserDefaults.standard.set(pasteBehavior.rawValue, forKey: "pasteBehavior")
        }
    }
    
    // Last successful serial port baudrate persistence
    @Published var lastBaudrate: Int {
        didSet {
            UserDefaults.standard.set(lastBaudrate, forKey: "lastBaudrate")
        }
    }
    
    // Preferred baudrate for serial port connection
    @Published var preferredBaudrate: BaudrateOption {
        didSet {
            UserDefaults.standard.set(preferredBaudrate.rawValue, forKey: "preferredBaudrate")
        }
    }
    
    // Gravity settings for both content and video layers
    @Published var gravity: GravityOption = .resizeAspect {
        didSet {
            UserDefaults.standard.set(gravity.rawValue, forKey: "gravity")
            // Notify interested parties (e.g., PlayerView) about gravity change
            NotificationCenter.default.post(name: Notification.Name.gravitySettingsChanged, object: nil)
        }
    }
    
    // Mouse event throttling Hz limit (events per second)
    @Published var mouseEventThrottleHz: Int = 60 {
        didSet {
            UserDefaults.standard.set(mouseEventThrottleHz, forKey: "mouseEventThrottleHz")
        }
    }
    
    // Control mode setting for the HID chip
    @Published var controlMode: ControlMode {
        didSet {
            UserDefaults.standard.set(controlMode.rawValue, forKey: "controlMode")
        }
    }
    
    // Always on top window setting
    @Published var isAlwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(isAlwaysOnTop, forKey: "isAlwaysOnTop")
        }
    }
    
    // Target Screen placement setting
    @Published var targetComputerPlacement: TargetComputerPlacement {
        didSet {
            UserDefaults.standard.set(targetComputerPlacement.rawValue, forKey: "targetComputerPlacement")
        }
    }

    // Connection protocol mode setting
    @Published var connectionProtocolMode: ConnectionProtocolMode {
        didSet {
            // Intentionally not persisted: app always defaults to KVM on startup.
        }
    }

    // VNC host name or IP
    @Published var vncHost: String {
        didSet {
            UserDefaults.standard.set(vncHost, forKey: "vncHost")
        }
    }

    // VNC username (used for Apple ARD / macOS Screen Sharing authentication)
    @Published var vncUsername: String {
        didSet {
            UserDefaults.standard.set(vncUsername, forKey: "vncUsername")
        }
    }

    // VNC TCP port
    @Published var vncPort: Int {
        didSet {
            let clampedPort = max(1, min(vncPort, 65535))
            if clampedPort != vncPort {
                vncPort = clampedPort
                return
            }
            UserDefaults.standard.set(vncPort, forKey: "vncPort")
        }
    }

    // VNC password stored in Keychain
    @Published var vncPassword: String {
        didSet {
            if vncPassword.isEmpty {
                VNCKeychainStore.deletePassword()
            } else {
                VNCKeychainStore.savePassword(vncPassword)
            }
        }
    }

    // Chat companion window visibility
    @Published var isChatWindowVisible: Bool {
        didSet {
            UserDefaults.standard.set(isChatWindowVisible, forKey: "isChatWindowVisible")
        }
    }

    // Chat companion dock side
    @Published var chatDockSide: ChatDockSide {
        didSet {
            UserDefaults.standard.set(chatDockSide.rawValue, forKey: "chatDockSide")
        }
    }

    // Chat companion preferred width
    @Published var chatWindowWidth: Double {
        didSet {
            UserDefaults.standard.set(chatWindowWidth, forKey: "chatWindowWidth")
        }
    }

    // Enables/disables tool-calling agentic workflow in chat.
    @Published var isChatAgenticModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isChatAgenticModeEnabled, forKey: "isChatAgenticModeEnabled")
        }
    }

    // OpenAI-compatible base URL (e.g. https://api.openai.com/v1)
    @Published var chatApiBaseURL: String {
        didSet {
            UserDefaults.standard.set(chatApiBaseURL, forKey: "chatApiBaseURL")
        }
    }

    // API key used for OpenAI-compatible chat requests
    @Published var chatApiKey: String {
        didSet {
            if chatApiKey.isEmpty {
                ChatKeychainStore.deleteChatAPIKey()
            } else {
                ChatKeychainStore.saveChatAPIKey(chatApiKey)
            }
        }
    }

    // Chat model name for /chat/completions
    @Published var chatModel: String {
        didSet {
            UserDefaults.standard.set(chatModel, forKey: "chatModel")
        }
    }

    // Optional system prompt prepended to chat context
    @Published var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        }
    }

    // Enables planner + task-agent workflow in chat.
    @Published var isChatPlannerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isChatPlannerModeEnabled, forKey: "isChatPlannerModeEnabled")
        }
    }

    // Enables non-executing guide mode in chat.
    @Published var isChatGuideModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isChatGuideModeEnabled, forKey: "isChatGuideModeEnabled")
        }
    }

    // Prompt used by the main planning agent.
    @Published var plannerPrompt: String {
        didSet {
            UserDefaults.standard.set(plannerPrompt, forKey: "plannerPrompt")
        }
    }

    // Prompt used by the screen-only task agent.
    @Published var screenAgentPrompt: String {
        didSet {
            UserDefaults.standard.set(screenAgentPrompt, forKey: "screenAgentPrompt")
        }
    }

    // Prompt used by the type_text task agent.
    @Published var typingAgentPrompt: String {
        didSet {
            UserDefaults.standard.set(typingAgentPrompt, forKey: "typingAgentPrompt")
        }
    }

    // Prompt used by guide mode for single-step user guidance.
    @Published var guidePrompt: String {
        didSet {
            UserDefaults.standard.set(guidePrompt, forKey: "guidePrompt")
        }
    }

    // Max screenshot size sent to the AI provider.
    @Published var chatImageUploadLimit: ChatImageUploadLimit {
        didSet {
            UserDefaults.standard.set(chatImageUploadLimit.rawValue, forKey: "chatImageUploadLimit")
        }
    }

    // Persisted active video area (stored in image pixels)
    @Published var activeVideoX: Int {
        didSet { UserDefaults.standard.set(activeVideoX, forKey: "activeVideoX") }
    }
    @Published var activeVideoY: Int {
        didSet { UserDefaults.standard.set(activeVideoY, forKey: "activeVideoY") }
    }
    @Published var activeVideoWidth: Int {
        didSet { UserDefaults.standard.set(activeVideoWidth, forKey: "activeVideoWidth") }
    }
    @Published var activeVideoHeight: Int {
        didSet { UserDefaults.standard.set(activeVideoHeight, forKey: "activeVideoHeight") }
    }

    // Convenience computed rect
    var activeVideoRect: CGRect {
        return CGRect(x: activeVideoX, y: activeVideoY, width: activeVideoWidth, height: activeVideoHeight)
    }
}

enum MouseControlMode: Int {
    case relativeHID = 0
    case relativeEvents = 1
    case absolute = 2
    
    var displayName: String {
        switch self {
        case .relativeHID:
            return "Relative (HID)"
        case .relativeEvents:
            return "Relative (Events)"
        case .absolute:
            return "Absolute"
        }
    }
    
    var description: String {
        switch self {
        case .relativeHID:
            return "Relative mouse control via HID (requires accessibility permissions)"
        case .relativeEvents:
            return "Relative mouse control via window events (no extra permissions)"
        case .absolute:
            return "Absolute mouse positioning"
        }
    }
}

// Paste behavior options
enum PasteBehavior: String, CaseIterable {
    case askEveryTime = "askEveryTime"
    case alwaysPasteToTarget = "alwaysPasteToTarget" 
    case alwaysPassToTarget = "alwaysPassToTarget"
    
    var displayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Every Time"
        case .alwaysPasteToTarget:
            return "Always Host Paste"
        case .alwaysPassToTarget:
            return "Always Local Paste"
        }
    }
    
    var menuDisplayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Every Time"
        case .alwaysPasteToTarget:
            return "Host Paste"
        case .alwaysPassToTarget:
            return "Local Paste"
        }
    }
}

// Keyboard layout enumeration
enum KeyboardLayout: String, CaseIterable {
    case windows = "windows"
    case mac = "mac"
    
    var displayName: String {
        switch self {
        case .windows:
            return "Windows Mode"
        case .mac:
            return "Mac Mode"
        }
    }
    
    var description: String {
        switch self {
        case .windows:
            return "Optimized for Windows targets"
        case .mac:
            return "Optimized for Mac targets"
        }
    }
}

enum ConnectionProtocolMode: String, CaseIterable {
    case kvm = "kvm"
    case vnc = "vnc"

    var displayName: String {
        switch self {
        case .kvm:
            return "Hardware KVM"
        case .vnc:
            return "VNC Client"
        }
    }

    var description: String {
        switch self {
        case .kvm:
            return "Use direct Openterface USB capture and HID control"
        case .vnc:
            return "Connect to a remote host using RFB/VNC"
        }
    }
}

// Aspect ratio mode enumeration - determines which aspect ratio source to use
enum AspectRatioMode: String, CaseIterable {
    case custom = "custom"           // User-specified custom aspect ratio
    case hidResolution = "hid"       // From HID resolution query (capture card info)
    case activeResolution = "active" // From active video area detection
    
    var displayName: String {
        switch self {
        case .custom:
            return "Custom Aspect Ratio"
        case .hidResolution:
            return "HID Resolution (Device Info)"
        case .activeResolution:
            return "Active Resolution (Auto-Detect)"
        }
    }
    
    var description: String {
        switch self {
        case .custom:
            return "Use a custom aspect ratio specified by the user"
        case .hidResolution:
            return "Use HID resolution from the capture card (may have blank areas)"
        case .activeResolution:
            return "Auto-detect the active video area periodically"
        }
    }
}

// Screen ratio option enumeration
enum AspectRatioOption: String, CaseIterable {
    case ratio21_9 = "21:9"     //2.33333333
    case ratio32_15 = "32:15"   //2.13333333 (eg: 1920x900, 1280x600)
    case ratio23_11 = "23:11"   //2.09090909 (eg: 2304x1100)
    case ratio2_1 = "2:1"       //2          (eg: 960x480)
    case ratio9_5 = "9:5"       //1.8       (eg: 4096x2160)
    case ratio16_9 = "16:9"     //1.77778   (eg: 1920x1080, 3840x2160)
    case ratio16_10 = "16:10"   //1.6       (eg: 2560x1600, 1920x1200)
    case ratio5_3 = "5:3"       //1.66667   (eg: 2560x1536, 1920x1152)
    case ratio211_135 = "211:135" //1.56296296 (Special handling for 1280:768, the capture card will return such a aspect ratio)
    case ratio3_2 = "3:2"       //1.5
    case ratio4_3 = "4:3"       //1.33333   (eg: 1600x1200, 1024x768)
    case ratio5_4 = "5:4"       //1.25      (eg: 1280x1024)
    case ratio211_180 = "211:180" //1.17222222 (Special handling for 1266:1080, the capture card will return such a aspect ratio)
    case ratio9_16 = "9:16"     //0.5625        
    case ratio9_19_5 = "9:19.5" // 0.46153846 
    case ratio9_20 = "9:20"     // 0.45
    case ratio9_21 = "9:21"     // 0.42857143
    case ratio228_487 = "228:487" // 0.468

    var widthToHeightRatio: CGFloat {
        switch self {
        case .ratio4_3:
            return 4.0 / 3.0
        case .ratio16_9:
            return 16.0 / 9.0
        case .ratio16_10:
            return 16.0 / 10.0
        case .ratio5_3:
            return 5.0 / 3.0
        case .ratio5_4:
            return 5.0 / 4.0
        case .ratio21_9:
            return 21.0 / 9.0
        case .ratio211_135:
            return 211.0 / 135.0
        case .ratio211_180:
            return 211.0 / 180.0
        case .ratio23_11:
            return 23.0 / 11.0
        case .ratio3_2:
            return 3.0/2.0
        case .ratio2_1:
            return 2.0 / 1.0
        case .ratio32_15:
            return 32.0 / 15.0
        case .ratio9_16:
            return 9.0 / 16.0
        case .ratio9_19_5:
            return 9.0 / 19.5
        case .ratio9_20:
            return 9.0 / 20.0
        case .ratio9_21:
            return 9.0 / 21.0
        case .ratio9_5:
            return 9.0 / 5.0
        case .ratio228_487:
            return 228.0 / 487.0
        }
    }
    
    var toString: String {
        return self.rawValue
    }
}

// Baudrate option enumeration
enum BaudrateOption: Int, CaseIterable {
    case lowSpeed = 9600
    case highSpeed = 115200
    
    var displayName: String {
        switch self {
        case .lowSpeed:
            return "9600 bps (Low Speed)"
        case .highSpeed:
            return "115200 bps (High Speed)"
        }
    }
    
    var description: String {
        switch self {
        case .lowSpeed:
            return "Slower, more reliable connection"
        case .highSpeed:
            return "Faster data transmission"
        }
    }
}

// Gravity option enumeration for video layer scaling
enum GravityOption: String, CaseIterable {
    case resize = "Stretch"
    case resizeAspect = "Fit"
    case resizeAspectFill = "Fill"
    
    var displayName: String {
        switch self {
        case .resize:
            return "Stretch to Fit"
        case .resizeAspect:
            return "Fit (Maintain Aspect Ratio)"
        case .resizeAspectFill:
            return "Fill (Maintain Aspect Ratio)"
        }
    }
    
    var description: String {
        switch self {
        case .resize:
            return "Stretches content to fill the entire view"
        case .resizeAspect:
            return "Fits content while preserving aspect ratio"
        case .resizeAspectFill:
            return "Fills view while preserving aspect ratio (may crop)"
        }
    }
    
    var contentsGravity: CALayerContentsGravity {
        switch self {
        case .resize:
            return .resize
        case .resizeAspect:
            return .resizeAspect
        case .resizeAspectFill:
            return .resizeAspectFill
        }
    }
    
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .resize:
            return .resize
        case .resizeAspect:
            return .resizeAspect
        case .resizeAspectFill:
            return .resizeAspectFill
        }
    }
}
// Control mode enumeration for HID chip operation
enum ControlMode: Int, CaseIterable {
    case performance = 0x00        // Performance mode
    case keyboardOnly = 0x01       // Keyboard only mode
    case compatibility = 0x82      // Compatibility mode (default)
    case customHID = 0x03          // Custom HID mode
    
    var displayName: String {
        switch self {
        case .performance:
            return "Performance Mode"
        case .keyboardOnly:
            return "Keyboard Only"
        case .compatibility:
            return "Compatibility Mode"
        case .customHID:
            return "Custom HID"
        }
    }
    
    var description: String {
        switch self {
        case .performance:
            return "Optimized for maximum performance"
        case .keyboardOnly:
            return "Keyboard input only"
        case .compatibility:
            return "Maximum compatibility with target devices (default)"
        case .customHID:
            return "Custom HID configuration"
        }
    }
    
    var modeByteValue: UInt8 {
        return UInt8(self.rawValue)
    }
}

// Target Screen placement enumeration
enum TargetComputerPlacement: String, CaseIterable {
    case left = "left"
    case right = "right"
    case top = "top"
    case bottom = "bottom"
    
    var displayName: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }
    
    var description: String {
        switch self {
        case .left:
            return "Target Screen positioned to the left"
        case .right:
            return "Target Screen positioned to the right"
        case .top:
            return "Target Screen positioned at the top"
        case .bottom:
            return "Target Screen positioned at the bottom"
        }
    }
}

enum ChatDockSide: String, CaseIterable {
    case left = "left"
    case right = "right"

    var displayName: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }
}

enum ChatImageUploadLimit: String, CaseIterable, Identifiable {
    case original = "original"
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            return "Original"
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p1440:
            return "1440p"
        }
    }

    var detail: String {
        switch self {
        case .original:
            return "Send screenshots at their original resolution."
        case .p720:
            return "Scale larger screenshots down to fit within 1280x720."
        case .p1080:
            return "Scale larger screenshots down to fit within 1920x1080."
        case .p1440:
            return "Scale larger screenshots down to fit within 2560x1440."
        }
    }

    var maxLongEdge: CGFloat? {
        switch self {
        case .original:
            return nil
        case .p720:
            return 1280
        case .p1080:
            return 1920
        case .p1440:
            return 2560
        }
    }
}

private enum ChatKeychainStore {
    private static let service = "com.openterface.chat"
    private static let account = "ai_api_key"

    static func loadChatAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveChatAPIKey(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func deleteChatAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}

private enum VNCKeychainStore {
    private static let service = "com.openterface.vnc"
    private static let account = "vnc_password"

    static func loadPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func savePassword(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
