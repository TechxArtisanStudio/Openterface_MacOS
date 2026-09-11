import Foundation

// MARK: - ChatToolExecutionService
// Agentic tool-call parser/dispatcher and bash command runner.
// Previously in ChatManager+ToolExecution.swift.
// Accessed through ChatManager's `toolExecution` property.

@MainActor
final class ChatToolExecutionService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Tool-call parsing

    func parseToolCalls(from text: String) -> [AgentToolCall]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("tool") else { return nil }

        let candidate: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            candidate = String(trimmed[start...end])
        } else {
            return nil
        }

        guard let data = candidate.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dict = json as? [String: Any],
           let calls = dict["tool_calls"] as? [[String: Any]] {
            return calls.compactMap { call in
                guard let tool = call["tool"] as? String else { return nil }
                var args = call
                args.removeValue(forKey: "tool")
                return AgentToolCall(tool: tool, args: args)
            }
        }

        if let dict = json as? [String: Any], let tool = dict["tool"] as? String {
            var args = dict
            args.removeValue(forKey: "tool")
            return [AgentToolCall(tool: tool, args: args)]
        }

        return nil
    }

    // MARK: - Tool dispatch

    func executeToolCalls(_ calls: [AgentToolCall]) async -> AgentToolExecutionResult {
        var summaries: [String] = []
        var attachmentPath: String?
        var keyboardTokens: [String] = []
        var hasNonKeyboardTool = false

        for call in calls {
            let toolName = call.tool.lowercased()
            switch toolName {

            case "capture_screen", "take_screenshot", "screenshot":
                hasNonKeyboardTool = true
                if let fileURL = await context.captureScreenForAgent() {
                    attachmentPath = fileURL.path
                    summaries.append("capture_screen: success")
                    context.logger.log(content: "AI Tool executed: capture_screen -> \(fileURL.path)")
                } else {
                    summaries.append("capture_screen: failed (no image captured)")
                    context.logger.log(content: "AI Tool failed: capture_screen")
                }

            case "move_mouse":
                hasNonKeyboardTool = true
                if let nx = doubleArg(call.args["x"]), let ny = doubleArg(call.args["y"]) {
                    let absX = normalizedToAbsolute(nx)
                    let absY = normalizedToAbsolute(ny)
                    AIInputRouter.sendMouseMove(absX: absX, absY: absY)
                    context.agentMouseX = absX
                    context.agentMouseY = absY
                    summaries.append("move_mouse: ok (x=\(String(format: "%.3f", nx)), y=\(String(format: "%.3f", ny)))")
                    context.logger.log(content: "AI Tool executed: move_mouse normalized=(\(nx), \(ny)) abs=(\(absX), \(absY))")
                } else {
                    summaries.append("move_mouse: invalid args")
                    context.logger.log(content: "AI Tool failed: move_mouse invalid args")
                }

            case "left_click":
                hasNonKeyboardTool = true
                let clickPoint = await click(button: 0x01, args: call.args)
                let lnx = absoluteToNormalized(clickPoint.x)
                let lny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await context.screenCapture.captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "left_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("left_click: success (x=\(String(format: "%.3f", lnx)), y=\(String(format: "%.3f", lny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("left_click: success (x=\(String(format: "%.3f", lnx)), y=\(String(format: "%.3f", lny)), image=unavailable)")
                }
                context.logger.log(content: "AI Tool executed: left_click normalized=(\(lnx), \(lny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "left_drag", "drag_mouse", "mouse_drag", "drag":
                hasNonKeyboardTool = true
                guard let dragPoints = dragPoints(from: call.args) else {
                    summaries.append("left_drag: invalid args")
                    context.logger.log(content: "AI Tool failed: left_drag invalid args")
                    continue
                }
                AIInputRouter.animatedDrag(
                    button: 0x01,
                    startAbsX: dragPoints.startX,
                    startAbsY: dragPoints.startY,
                    endAbsX: dragPoints.endX,
                    endAbsY: dragPoints.endY
                )
                context.agentMouseX = dragPoints.endX
                context.agentMouseY = dragPoints.endY
                let startNX = absoluteToNormalized(dragPoints.startX)
                let startNY = absoluteToNormalized(dragPoints.startY)
                let endNX   = absoluteToNormalized(dragPoints.endX)
                let endNY   = absoluteToNormalized(dragPoints.endY)
                if let annotatedURL = await context.screenCapture.captureAnnotatedClickForChat(absX: dragPoints.endX, absY: dragPoints.endY, actionName: "left_drag") {
                    attachmentPath = annotatedURL.path
                    summaries.append("left_drag: success (start_x=\(String(format: "%.3f", startNX)), start_y=\(String(format: "%.3f", startNY)), x=\(String(format: "%.3f", endNX)), y=\(String(format: "%.3f", endNY)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("left_drag: success (start_x=\(String(format: "%.3f", startNX)), start_y=\(String(format: "%.3f", startNY)), x=\(String(format: "%.3f", endNX)), y=\(String(format: "%.3f", endNY)), image=unavailable)")
                }
                context.logger.log(content: "AI Tool executed: left_drag start=(\(dragPoints.startX), \(dragPoints.startY)) end=(\(dragPoints.endX), \(dragPoints.endY))")

            case "right_click":
                hasNonKeyboardTool = true
                let clickPoint = await click(button: 0x02, args: call.args)
                let rnx = absoluteToNormalized(clickPoint.x)
                let rny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await context.screenCapture.captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "right_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("right_click: success (x=\(String(format: "%.3f", rnx)), y=\(String(format: "%.3f", rny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("right_click: success (x=\(String(format: "%.3f", rnx)), y=\(String(format: "%.3f", rny)), image=unavailable)")
                }
                context.logger.log(content: "AI Tool executed: right_click normalized=(\(rnx), \(rny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "double_click":
                hasNonKeyboardTool = true
                let clickPoint = await click(button: 0x01, args: call.args, isDoubleClick: true)
                let dnx = absoluteToNormalized(clickPoint.x)
                let dny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await context.screenCapture.captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "double_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("double_click: success (x=\(String(format: "%.3f", dnx)), y=\(String(format: "%.3f", dny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("double_click: success (x=\(String(format: "%.3f", dnx)), y=\(String(format: "%.3f", dny)), image=unavailable)")
                }
                context.logger.log(content: "AI Tool executed: double_click normalized=(\(dnx), \(dny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "type_text":
                let text = (call.args["text"] as? String) ?? ""
                if !text.isEmpty { keyboardTokens.append(text) }
                if text.isEmpty {
                    summaries.append("type_text: empty text")
                    context.logger.log(content: "AI Tool failed: type_text empty")
                } else {
                    let looksLikeTokenSequence = text.contains("<") && text.contains(">")
                    if looksLikeTokenSequence {
                        let tokens = MacroManager.shared.tokenize(text)
                        DispatchQueue.global(qos: .userInitiated).sync {
                            MacroExecutionEngine.run(tokens: tokens, intervalMs: 80)
                        }
                        summaries.append("type_text(redirected to press_key): success (keys=\"\(text)\")")
                        context.logger.log(content: "AI Tool type_text redirected to press_key: keys=\(text)")
                    } else {
                        AIInputRouter.sendText(text)
                        summaries.append("type_text: success (chars=\(text.count), text=\"\(text)\")")
                        context.logger.log(content: "AI Tool executed: type_text chars=\(text.count)")
                    }
                }

            case "press_key", "key_press", "send_key", "hotkey":
                let keys = ((call.args["keys"] as? String) ?? (call.args["key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !keys.isEmpty { keyboardTokens.append(keys) }
                if keys.isEmpty {
                    summaries.append("press_key: missing keys argument")
                    context.logger.log(content: "AI Tool failed: press_key missing keys")
                } else {
                    let tokens = MacroManager.shared.tokenize(keys)
                    DispatchQueue.global(qos: .userInitiated).sync {
                        MacroExecutionEngine.run(tokens: tokens, intervalMs: 80)
                    }
                    summaries.append("press_key: success (keys=\"\(keys)\")")
                    context.logger.log(content: "AI Tool executed: press_key keys=\(keys)")
                }

            case "run_verified_macro", "execute_verified_macro", "invoke_verified_macro":
                hasNonKeyboardTool = true
                if let match = context.conversationBuilder.verifiedMacroMatch(from: call.args) {
                    let estimatedDuration = MacroManager.shared.estimatedExecutionDuration(for: match.macro)
                    MacroManager.shared.execute(match.macro)
                    let waitDuration = estimatedDuration + 2.0
                    context.logger.log(content: "AI Tool waiting \(String(format: "%.1f", waitDuration))s for macro completion (estimated=\(String(format: "%.1f", estimatedDuration))s)")
                    try? await Task.sleep(nanoseconds: UInt64(waitDuration * 1_000_000_000))
                    summaries.append("run_verified_macro: success (matchedBy=\(match.matchedBy), id=\(match.macro.id.uuidString), label=\"\(match.macro.label)\", waitedSeconds=\(String(format: "%.1f", waitDuration)))")
                    summaries.append("run_verified_macro_note: the macro keystrokes have finished; now verify the new screen state with capture_screen before any click")
                    context.logger.log(content: "AI Tool executed: run_verified_macro id=\(match.macro.id.uuidString), label=\(match.macro.label), matchedBy=\(match.matchedBy)")
                } else {
                    let available = MacroManager.shared.macros
                        .filter(\.isVerified)
                        .map { "\($0.label) [\($0.id.uuidString)]" }
                        .joined(separator: ", ")
                    let inventory = available.isEmpty ? "none" : available
                    summaries.append("run_verified_macro: no verified macro matched the request (available=\(inventory))")
                    context.logger.log(content: "AI Tool failed: run_verified_macro no verified macro matched; available=\(inventory)")
                }

            case "create_macro", "new_macro", "add_macro":
                hasNonKeyboardTool = true
                let label = (call.args["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let data  = (call.args["data"]  as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if label.isEmpty || data.isEmpty {
                    summaries.append("create_macro: missing required args label and/or data")
                    context.logger.log(content: "AI Tool failed: create_macro missing label or data")
                } else {
                    let description  = (call.args["description"]   as? String) ?? ""
                    let intervalMs   = intArg(call.args["interval_ms"]) ?? 80
                    let verifiedArg  = (call.args["verified"] as? Bool) ?? false
                    let targetRaw    = (call.args["target_system"] as? String) ?? UserSettings.shared.chatTargetSystem.rawValue
                    let targetSystem = MacroTargetSystem(rawValue: targetRaw)
                        ?? MacroTargetSystem(rawValue: UserSettings.shared.chatTargetSystem.rawValue)
                        ?? .macOS
                    let newMacro = Macro(
                        label: label,
                        description: description,
                        isVerified: verifiedArg,
                        data: data,
                        targetSystem: targetSystem,
                        intervalMs: intervalMs
                    )
                    MacroManager.shared.add(newMacro)
                    summaries.append("create_macro: success (id=\(newMacro.id.uuidString), label=\"\(label)\", verified=\(verifiedArg), target=\(targetSystem.displayName))")
                    context.logger.log(content: "AI Tool executed: create_macro id=\(newMacro.id.uuidString), label=\(label)")
                }

            case "set_macro_verified", "verify_macro", "unverify_macro", "update_macro_verified":
                hasNonKeyboardTool = true
                let verifiedArg = (call.args["verified"] as? Bool) ?? true
                if let match = context.conversationBuilder.anyMacroMatch(from: call.args) {
                    if let idx = MacroManager.shared.macros.firstIndex(where: { $0.id == match.macro.id }) {
                        var updated = match.macro
                        updated.isVerified = verifiedArg
                        MacroManager.shared.update(updated, at: idx)
                        summaries.append("set_macro_verified: success (matchedBy=\(match.matchedBy), id=\(match.macro.id.uuidString), label=\"\(match.macro.label)\", verified=\(verifiedArg))")
                        context.logger.log(content: "AI Tool executed: set_macro_verified id=\(match.macro.id.uuidString), label=\(match.macro.label), verified=\(verifiedArg)")
                    } else {
                        summaries.append("set_macro_verified: macro not found in list after match")
                    }
                } else {
                    let all = MacroManager.shared.macros.map { "\($0.label) [\($0.id.uuidString)]" }.joined(separator: ", ")
                    let allDisplay = all.isEmpty ? "none" : all
                    summaries.append("set_macro_verified: no macro matched (all=\(allDisplay))")
                    context.logger.log(content: "AI Tool failed: set_macro_verified no match")
                }

            case "run_bash", "bash", "shell", "exec_command":
                hasNonKeyboardTool = true
                let command = (call.args["command"] as? String) ?? ""
                if command.isEmpty {
                    summaries.append("run_bash: missing command argument")
                    context.logger.log(content: "AI Tool failed: run_bash missing command")
                } else {
                    let result = await runBashCommand(command)
                    summaries.append("run_bash: \(result)")
                    context.logger.log(content: "AI Tool executed: run_bash command=\(command)")
                }

            default:
                hasNonKeyboardTool = true
                summaries.append("\(toolName): unsupported")
                context.logger.log(content: "AI Tool unsupported: \(toolName)")
            }
        }

        let macroData = (!hasNonKeyboardTool && !keyboardTokens.isEmpty) ? keyboardTokens.joined() : nil
        return AgentToolExecutionResult(summary: summaries.joined(separator: "\n"), attachmentFilePath: attachmentPath, keyboardOnlyMacroData: macroData)
    }

    // MARK: - Bash runner

    func runBashCommand(_ command: String) async -> String {
        await Task.detached(priority: .utility) {
            let workDir: URL = {
                let docs = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let dir = docs.appendingPathComponent("Openterface", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workDir

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe

            do {
                try process.run()
            } catch {
                return "launch_error: \(error.localizedDescription)"
            }

            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout  = String(data: outData, encoding: .utf8) ?? ""
            let stderr  = String(data: errData, encoding: .utf8) ?? ""
            let combined = (stdout + (stderr.isEmpty ? "" : "\n[stderr]: " + stderr))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = combined.count > 8192
                ? String(combined.prefix(8192)) + "\n[output truncated at 8192 chars]"
                : combined
            let exitCode = process.terminationStatus
            return "exit=\(exitCode) output=\(truncated.isEmpty ? "(empty)" : truncated)"
        }.value
    }

    // MARK: - Coordinate helpers

    func intArg(_ value: Any?) -> Int? {
        if let v = value as? Int    { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }

    func doubleArg(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int    { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    func dragPoints(from args: [String: Any]) -> (startX: Int, startY: Int, endX: Int, endY: Int)? {
        let resolvedEndX: Int
        let resolvedEndY: Int
        if let nx = doubleArg(args["x"]), let ny = doubleArg(args["y"]) {
            resolvedEndX = normalizedToAbsolute(nx)
            resolvedEndY = normalizedToAbsolute(ny)
        } else if let nx = doubleArg(args["end_x"]), let ny = doubleArg(args["end_y"]) {
            resolvedEndX = normalizedToAbsolute(nx)
            resolvedEndY = normalizedToAbsolute(ny)
        } else {
            return nil
        }

        let resolvedStartX: Int
        let resolvedStartY: Int
        if let nx = doubleArg(args["start_x"]), let ny = doubleArg(args["start_y"]) {
            resolvedStartX = normalizedToAbsolute(nx)
            resolvedStartY = normalizedToAbsolute(ny)
        } else {
            resolvedStartX = context.agentMouseX
            resolvedStartY = context.agentMouseY
        }

        return (resolvedStartX, resolvedStartY, resolvedEndX, resolvedEndY)
    }

    func normalizedToAbsolute(_ value: Double) -> Int {
        max(0, min(4096, Int((min(max(value, 0.0), 1.0) * 4096.0).rounded())))
    }

    func absoluteToNormalized(_ value: Int) -> Double {
        min(max(Double(value) / 4096.0, 0.0), 1.0)
    }

    func click(button: UInt8, args: [String: Any], isDoubleClick: Bool = false) async -> (x: Int, y: Int) {
        var x: Int
        var y: Int
        if let nx = doubleArg(args["x"]), let ny = doubleArg(args["y"]) {
            x = normalizedToAbsolute(nx)
            y = normalizedToAbsolute(ny)
        } else {
            x = context.agentMouseX
            y = context.agentMouseY
        }

        if let instruction = context.screenCapture.agenticClickRefinementInstruction(args: args, isDoubleClick: isDoubleClick, button: button),
           let refinedPoint = await context.screenCapture.refineClickTarget(
                absX: x,
                absY: y,
                instruction: instruction,
                tracePrefix: "AGENTIC_CLICK_REFINE",
                logPrefix: "Agentic click refinement"
           ) {
            x = refinedPoint.x
            y = refinedPoint.y
            if let matchedElement = refinedPoint.matchedElement, !matchedElement.isEmpty {
                context.logger.log(content: "Agentic click refinement matched element: \(matchedElement)")
            }
        }

        context.agentMouseX = x
        context.agentMouseY = y

        AIInputRouter.animatedClick(button: button, absX: x, absY: y, isDoubleClick: isDoubleClick)
        return (x, y)
    }
}
