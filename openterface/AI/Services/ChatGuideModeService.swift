import Foundation
import AppKit

// MARK: - ChatGuideModeService
// Guide-action execution, auto-next, input-sequence dispatch, and shortcut mapping.
// Previously in ChatManager+GuideMode.swift.
// Accessed through ChatManager's `guideMode` property.

@MainActor
final class ChatGuideModeService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    private static func clamp(_ value: Int) -> Int { max(0, min(4096, value)) }

    // MARK: - Guide completion detection

    func isGuideCompletionText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("result:") { return true }
        let completionPhrases = [
            "goal achieved",
            "task complete",
            "task completed",
            "already open and loaded",
            "already completed",
            "is already open",
            "is already loaded"
        ]
        return completionPhrases.contains { normalized.contains($0) }
    }

    // MARK: - Guide action

    func executeGuideAction(messageID: UUID, targetBox: CGRect?, shortcut: String?, tool: String?, messageContent: String, autoNext: Bool) {
        let anchorUserMessageID = context.messages.last(where: { $0.role == .user })?.id
        Task {
            var actionDescription = "unknown"

            if let shortcut = shortcut, !shortcut.isEmpty {
                context.logger.log(content: "Guide Action Preparing: executing input sequence '\(shortcut)'")
                let success = executeGuideInputSequence(shortcut)
                actionDescription = "input sequence \(shortcut) (Success: \(success))"
                context.logger.log(content: "Guide Action Executed: \(actionDescription)")
            } else if let targetBox = targetBox {
                let cx = targetBox.midX
                let cy = targetBox.midY

                let normalizedTool = tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let contentLower   = messageContent.lowercased()
                let isRightClick   = normalizedTool == "right_click" || normalizedTool == "right-click" || contentLower.contains("right click") || contentLower.contains("right-click")
                let isDoubleClick  = (!isRightClick && (normalizedTool == "double_click" || normalizedTool == "double-click" || contentLower.contains("double click") || contentLower.contains("double-click")))

                let buttonEvent: UInt8 = isRightClick ? 0x02 : 0x01
                let actionName = isRightClick ? "right_click" : (isDoubleClick ? "double_click" : "left_click")

                let absX = Int(cx * 4096.0)
                let absY = Int(cy * 4096.0)
                var clampedX = Self.clamp(absX)
                var clampedY = Self.clamp(absY)

                if let refinedPoint = await context.screenCapture.refineGuideClickTarget(absX: clampedX, absY: clampedY, instruction: messageContent) {
                    clampedX = refinedPoint.x
                    clampedY = refinedPoint.y
                    if let matchedElement = refinedPoint.matchedElement, !matchedElement.isEmpty {
                        context.logger.log(content: "Guide click refinement matched element: \(matchedElement)")
                    }
                }
                context.agentMouseX = clampedX
                context.agentMouseY = clampedY

                context.logger.log(content: "Guide Action Preparing: \(actionName) at normalized(\(String(format: "%.3f", cx)), \(String(format: "%.3f", cy))) -> clamped(\(clampedX), \(clampedY))")
                AIInputRouter.animatedClick(button: buttonEvent, absX: clampedX, absY: clampedY, isDoubleClick: isDoubleClick)

                actionDescription = "\(actionName) at x=\(clampedX), y=\(clampedY)"
                context.logger.log(content: "Guide Action Executed: \(actionDescription)")
            }

            let messageText = autoNext
                ? "Action executed: \(actionDescription). Auto-guiding the next step..."
                : "Action executed: \(actionDescription)."

            DispatchQueue.main.async {
                self.context.clearGuideOverlay()
                if autoNext {
                    self.context.startGuideAutoNextStatus(for: messageID)
                } else {
                    self.context.messages.append(ChatMessage(role: .assistant, content: messageText))
                }
                self.context.persistHistory()
            }

            if autoNext {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                DispatchQueue.main.async {
                    let latestUserMessageID = self.context.messages.last(where: { $0.role == .user })?.id
                    guard latestUserMessageID == anchorUserMessageID else {
                        self.context.logger.log(content: "Guide auto-next canceled: detected newer user request (starting new mission context)")
                        self.context.cancelGuideAutoNextStatus(for: messageID)
                        return
                    }
                    if UserSettings.shared.isChatGuideModeEnabled {
                        self.context.sendMessage("Guide me to the next action on the current screen.")
                    }
                }
            }
        }
    }

    func completeGuideStepAndNext(stepDescription: String) {
        let firstLine = stepDescription
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let resultLine = firstLine.isEmpty
            ? "Result: I completed this guide step."
            : "Result: I completed this step: \(firstLine)"

        context.logger.log(content: "Guide Action User-Completed: \(resultLine)")
        context.clearGuideOverlay()
        context.sendMessage("\(resultLine)\nGuide me to the next action on the current screen.")
    }

    // MARK: - Input sequence execution

    func executeGuideInputSequence(_ inputSequence: String) -> Bool {
        let normalized = inputSequence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if normalized.contains("<") && normalized.contains(">") {
            return executeBracketedGuideInputSequence(normalized)
        }

        let steps = normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sequenceSteps = steps.isEmpty ? [normalized] : steps
        var executedAny = false

        for (index, step) in sequenceSteps.enumerated() {
            if executeShortcut(step) {
                executedAny = true
                let nextStep = index + 1 < sequenceSteps.count ? sequenceSteps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterPlainStep(step, nextStep: nextStep))
                continue
            }

            context.logger.log(content: "AI Executing Text Input: '\(step)'")
            AIInputRouter.sendText(step)
            executedAny = true
            let nextStep = index + 1 < sequenceSteps.count ? sequenceSteps[index + 1] : nil
            Thread.sleep(forTimeInterval: guideDelayAfterPlainTextStep(step, nextStep: nextStep))
        }

        return executedAny
    }

    private enum GuideInputStep {
        case shortcut(String)
        case text(String)
    }

    private func executeBracketedGuideInputSequence(_ input: String) -> Bool {
        let steps = parseBracketedGuideInputSteps(input)
        guard !steps.isEmpty else { return false }

        var executedAny = false

        for (index, step) in steps.enumerated() {
            switch step {
            case .shortcut(let shortcut):
                if executeShortcut(shortcut) { executedAny = true }
                let nextStep = index + 1 < steps.count ? steps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterBracketedStep(step, nextStep: nextStep))
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                context.logger.log(content: "AI Executing Text Input: '\(trimmed)'")
                AIInputRouter.sendText(trimmed)
                executedAny = true
                let nextStep = index + 1 < steps.count ? steps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterBracketedStep(step, nextStep: nextStep))
            }
        }

        return executedAny
    }

    // MARK: - Step delay heuristics

    private func guideDelayAfterPlainStep(_ step: String, nextStep: String?) -> TimeInterval {
        let normalized = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isGuideLauncherShortcut(normalized) { return 0.65 }
        if isGuideNavigationShortcut(normalized) { return 0.22 }
        if let nextStep,
           !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !looksLikeGuideShortcut(nextStep) {
            return 0.18
        }
        return 0.12
    }

    private func guideDelayAfterPlainTextStep(_ text: String, nextStep: String?) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.12 }
        if let nextStep {
            let n = nextStep.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if n == "enter" || n == "return" || n == "tab" { return 0.3 }
        }
        return 0.16
    }

    private func guideDelayAfterBracketedStep(_ step: GuideInputStep, nextStep: GuideInputStep?) -> TimeInterval {
        switch step {
        case .shortcut(let shortcut):
            if isGuideLauncherShortcut(shortcut) { return 0.65 }
            if isGuideNavigationShortcut(shortcut) { return 0.22 }
            return 0.12
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0.12 }
            if case .shortcut(let shortcut)? = nextStep {
                let n = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if n == "enter" || n == "return" || n == "tab" { return 0.3 }
            }
            return 0.16
        }
    }

    // MARK: - Shortcut classification

    private func isGuideLauncherShortcut(_ shortcut: String) -> Bool {
        let normalized = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let launcherShortcuts: Set<String> = [
            "cmd+space", "cmd+h", "cmd+tab", "ctrl+alt+t", "win+r", "win+e"
        ]
        return launcherShortcuts.contains(normalized)
    }

    private func isGuideNavigationShortcut(_ shortcut: String) -> Bool {
        let normalized = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let navigationShortcuts: Set<String> = [
            "enter", "return", "tab", "shift+tab",
            "up", "down", "left", "right",
            "esc", "escape"
        ]
        return navigationShortcuts.contains(normalized)
    }

    private func looksLikeGuideShortcut(_ step: String) -> Bool {
        let normalized = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("+") { return true }
        return isGuideNavigationShortcut(normalized) || isGuideLauncherShortcut(normalized)
    }

    // MARK: - Bracketed input parsing

    private func parseBracketedGuideInputSteps(_ input: String) -> [GuideInputStep] {
        var steps: [GuideInputStep] = []
        var textBuffer = ""
        var pendingModifiers: [String] = []

        func flushTextBuffer() {
            if !textBuffer.isEmpty { steps.append(.text(textBuffer)) }
            textBuffer = ""
        }

        func removePendingModifier(_ modifier: String) {
            if let index = pendingModifiers.lastIndex(of: modifier) {
                pendingModifiers.remove(at: index)
            }
        }

        func appendShortcut(using keyToken: String) {
            let key = keyToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            let comboTokens = pendingModifiers + [key]
            steps.append(.shortcut(comboTokens.joined(separator: "+")))
            pendingModifiers.removeAll()
        }

        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "<", let close = input[index...].firstIndex(of: ">") {
                let rawTag     = String(input[input.index(after: index)..<close])
                let cleanedTag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)

                if cleanedTag.hasPrefix("/") {
                    let closingToken = normalizeBracketedKeyToken(String(cleanedTag.dropFirst()))
                    if isModifierToken(closingToken) { removePendingModifier(closingToken) }
                } else {
                    flushTextBuffer()
                    let normalizedTag = normalizeBracketedKeyToken(cleanedTag)
                    if !normalizedTag.isEmpty {
                        if isModifierToken(normalizedTag) {
                            pendingModifiers.append(normalizedTag)
                        } else {
                            appendShortcut(using: normalizedTag)
                        }
                    }
                }

                index = input.index(after: close)
            } else {
                let char = input[index]
                if !pendingModifiers.isEmpty,
                   !char.isWhitespace,
                   char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(scalar) {
                    appendShortcut(using: String(char))
                } else {
                    textBuffer.append(char)
                }
                index = input.index(after: index)
            }
        }

        flushTextBuffer()
        pendingModifiers.removeAll()
        return steps
    }

    private func isModifierToken(_ token: String) -> Bool {
        switch token {
        case "ctrl", "alt", "shift", "cmd": return true
        default:                             return false
        }
    }

    private func normalizeBracketedKeyToken(_ token: String) -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "del":                                         return "delete"
        case "control":                                     return "ctrl"
        case "command", "meta", "super", "windows", "win": return "cmd"
        case "option":                                      return "alt"
        case "return":                                      return "enter"
        default:                                            return normalized
        }
    }

    // MARK: - Shortcut dispatch

    func executeShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let keyToken = parts.last else { return false }

        var modifiers: NSEvent.ModifierFlags = []
        for token in parts.dropLast() {
            switch token {
            case "win", "windows", "cmd", "command", "meta", "super":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                return false
            }
        }

        guard let code = keyCode(for: keyToken) else { return false }

        context.logger.log(content: "AI Executing Shortcut: '\(shortcut)' -> resolved mod: \(modifiers.rawValue), key: \(code)")
        return AIInputRouter.sendShortcut(keyCode: code, modifiers: modifiers)
    }

    func keyCode(for token: String) -> UInt16? {
        let named: [String: UInt16] = [
            "esc": 53, "escape": 53,
            "enter": 36, "return": 36,
            "tab": 48,
            "space": 49,
            "backspace": 51, "delete": 51,
            "home": 115,
            "end": 119,
            "pageup": 116,
            "pagedown": 121,
            "up": 126,
            "down": 125,
            "left": 123,
            "right": 124,
            "f1": 122, "f2": 120,  "f3": 99,  "f4": 118,
            "f5": 96,  "f6": 97,   "f7": 98,  "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        if let mapped = named[token] { return mapped }

        let alphaNumeric: [String: UInt16] = [
            "a": 0,  "b": 11, "c": 8,  "d": 2,  "e": 14, "f": 3,  "g": 5,  "h": 4,  "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,  "t": 17,
            "u": 32, "v": 9,  "w": 13, "x": 7,  "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return alphaNumeric[token]
    }
}
