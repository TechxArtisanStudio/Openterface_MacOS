# AI Chat Flow — High-Level Overview

## Entry Points

There are two ways a message enters the system:

| Entry | Code |
|-------|------|
| User types in the chat panel | `ChatManager.sendMessage(_:attachmentFileURL:)` |
| Skill panel button pressed | `ChatManager.runSkill(_:)` |

Both append a `ChatMessage(role: .user, …)` to `ChatManager.messages`, set `isSending = true`, then launch a `Task` that calls `routing.performSend()`.

---

## Router: `ChatRoutingService.performSend()`

The router validates credentials (base URL, model, API key) then branches into **one of three send paths** based on user settings:

```
performSend()
 ├─ isChatGuideModeEnabled  → performGuideSend()      (Guide Mode)
 ├─ isChatPlannerModeEnabled → performMultiAgentSend() (Planner Mode)
 └─ (default)               → standard/agentic loop   (Standard / Agentic Mode)
```

---

## Path 1 — Standard / Agentic Mode

```
performSend() — standard loop
 │
 ├─ (agentic only) osVerification.verifyAndConfirmTargetOS()
 │       Captures a screenshot, asks the AI to identify the OS,
 │       and may pause for user confirmation if ambiguous.
 │
 └─ for iteration in 1...maxAgentIterations:
       │
       ├─ conversationBuilder.buildConversation()
       │       Assembles system prompt + message history + tool definitions
       │       into the array of messages sent to the API.
       │
       ├─ POST /chat/completions  (URLSession)
       │
       ├─ (agentic) parseToolCalls(from: assistantText)
       │       Looks for a JSON block with "tool_calls" or "tool" key
       │       in the assistant reply.
       │
       ├─ tool calls found?
       │   YES → toolExecution.executeToolCalls()    ← see Tool Dispatch below
       │          append TOOL_RESULT, continue loop
       │
       └─ NO tool calls (or non-agentic) → append assistant message, done
```

---

## Path 2 — Guide Mode

Guide Mode is a single-shot interaction designed to drive the target device
step-by-step with visual overlays.

```
performGuideSend()
 │
 ├─ screenCapture.captureScreenForAgent()
 │       Takes a screenshot of the KVM video feed.
 │
 ├─ conversationBuilder.buildGuideConversation()
 │       Injects the screenshot + a structured guide prompt.
 │
 ├─ POST /chat/completions
 │
 ├─ Parse JSON response → GuideResponsePayload
 │       { action, targetBox, shortcut, tool, autoNext, … }
 │
 ├─ isGuideCompletionText()?
 │   YES → show "Goal achieved" overlay, done
 │
 └─ guideMode.executeGuideAction()
         ├─ shortcut  → executeGuideInputSequence()  (keyboard/HID)
         ├─ targetBox → screenCapture.refineGuideClickTarget()
         │              then AIInputRouter.animatedClick()
         └─ autoNext  → schedule next performGuideSend() iteration
```

---

## Path 3 — Planner (Multi-Agent) Mode

Planner Mode breaks a user request into a structured task list and executes
each task with a dedicated task-agent.

```
performMultiAgentSend()
 │
 ├─ screenCapture (optional) → attach current screen to planner context
 │
 ├─ plannerAgent.buildPlanningConversation()
 │       Uses MainPlannerAgent + TaskAgentRegistry to compose a prompt
 │       that includes the macro inventory and known OS.
 │
 ├─ POST /chat/completions  → raw plan JSON
 │
 ├─ Decode → ChatExecutionPlan  { tasks: [ChatPlanTask] }
 │
 ├─ Pause for user approval (plan displayed in UI)
 │   User clicks "Run" → planExecution.executeApprovedPlan()
 │
 └─ executeApprovedPlan()
       │
       ├─ osVerification.verifyAndConfirmTargetOS()
       │
       └─ for each task in plan:
             │
             ├─ Resolve task-agent from TaskAgentRegistry
             │       e.g. ScreenTaskAgent, TypeTextTaskAgent,
             │            MacroTaskAgent, MouseTaskAgent
             │
             ├─ agent.buildConversation() → POST /chat/completions
             │
             ├─ toolExecution.executeToolCalls()  (if tools present)
             │
             ├─ confirmTaskState()
             │       Takes a screenshot, asks the AI to verify
             │       the task outcome; retries up to 3 times.
             │
             └─ mark task .completed or .failed, update UI
```

---

## Tool Dispatch: `ChatToolExecutionService.executeToolCalls()`

Called by Paths 1 and 3 whenever the AI returns a tool-call block.

```
executeToolCalls([AgentToolCall])
 │
 ├─ "take_screenshot"   → screenCapture.captureScreenForAgent()
 ├─ "left_click"        → click(button: 0x01, …)
 ├─ "right_click"       → click(button: 0x02, …)
 ├─ "double_click"      → click(…, isDoubleClick: true)
 ├─ "move_mouse"        → AIInputRouter.moveMouse()
 ├─ "left_drag"         → AIInputRouter.drag()
 ├─ "type_text"         → AIInputRouter.typeText()
 ├─ "key_press"         → AIInputRouter.sendKeyCombo()
 ├─ "scroll"            → AIInputRouter.scroll()
 ├─ "run_macro"         → MacroManager.executeMacroByName()
 ├─ "bash"              → runBashCommand()  (macOS host only)
 └─ (unknown)           → log warning, skip
```

Each tool returns a text summary (and optional screenshot attachment) that is fed
back into the conversation as a `TOOL_RESULT:` user message.

---

## Supporting Services

| Service | Responsibility |
|---------|---------------|
| `ChatPersistenceService` | Load/save `messages` + `currentPlan` to disk as JSON |
| `ChatTracingService` | Append request/response/tool traces to the AI trace log |
| `ChatConversationBuilderService` | Build the messages array sent to the API; inject tool definitions, OS hints, macro inventory |
| `ChatMacroGenerationService` | Generate new macros from conversation; manage the AI draft workflow |
| `ChatOSVerificationService` | Screenshot → ask AI to identify target OS; handle user confirmation dialog |
| `ChatScreenCaptureService` | Take a KVM video-feed screenshot; guide-click refinement (crop + re-ask) |
| `ChatGuideModeService` | Guide overlay execution — click, keyboard shortcuts, auto-next scheduling |
| `ChatPlanExecutionService` | Run approved plans task-by-task; task state confirmation; `sendChatCompletion` HTTP helper |
| `ChatToolExecutionService` | Parse tool-call JSON; dispatch each tool to `AIInputRouter` or `MacroManager` |
| `ChatRoutingService` | `performSend` entry point; branch to the three paths above |

---

## Data Flow Diagram

```
User / Skill
     │
     ▼
ChatManager.sendMessage / runSkill
     │  append user ChatMessage
     ▼
ChatRoutingService.performSend
     │
     ├──[Guide Mode]──────────────────────────────────────────────────┐
     │   ChatScreenCaptureService                                      │
     │   → POST /chat/completions                                      │
     │   → ChatGuideModeService.executeGuideAction                     │
     │        → AIInputRouter (click / keyboard)                       │
     │   autoNext? → loop ─────────────────────────────────────────────┘
     │
     ├──[Planner Mode]────────────────────────────────────────────────┐
     │   MainPlannerAgent + TaskAgentRegistry                          │
     │   → POST /chat/completions → ChatExecutionPlan                  │
     │   UI approval pause                                             │
     │   ChatPlanExecutionService.executeApprovedPlan                  │
     │        for each task → TaskAgent → POST → executeToolCalls      │
     │                      → confirmTaskState (screenshot + verify)   │
     └────────────────────────────────────────────────────────────────┘
     │
     └──[Standard / Agentic]─────────────────────────────────────────┐
         (optional) ChatOSVerificationService                          │
         loop:                                                         │
           ChatConversationBuilderService.buildConversation            │
           → POST /chat/completions                                    │
           tool calls? → ChatToolExecutionService.executeToolCalls     │
                → AIInputRouter / MacroManager                         │
                → TOOL_RESULT → continue loop                          │
           no tools → append assistant reply, done ────────────────────┘
```
